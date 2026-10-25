// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import ObjectiveC
import Darwin
import TurtleGitCore

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

private struct HistoryServiceScopes: RepositoryBookmarkProvider {
    func create(for url: URL) throws -> Data { Data(url.path.utf8) }
    func resolve(_ data: Data) throws -> ResolvedBookmark { .init(url: URL(fileURLWithPath: String(decoding:data,as:UTF8.self)),stale:false) }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
}
/// A private injected daemon operation deliberately retains its cancellation
/// receipt until released. It never binds a socket or starts a public daemon.
private final class HistoryServiceDaemonGate: @unchecked Sendable {
    private let lock=NSLock()
    private var released=false, captured:OperationCancellation?, starts=0
    var token:OperationCancellation? {lock.lock();defer{lock.unlock()};return captured}
    var startCount:Int {lock.lock();defer{lock.unlock()};return starts}
    func release(){lock.lock();released=true;lock.unlock()}
    func run(_ token:OperationCancellation)->Int32 {
        lock.lock();captured=token;starts += 1;lock.unlock()
        while true {lock.lock();let done=released;lock.unlock();if done{break};Thread.sleep(forTimeInterval:0.01)}
        return token.isCancelled ? 130:0
    }
}
@main struct FinderHistoryServicesVerification {
    static let commands=["reflog","referenceBrowser","repositoryBrowser","revisionGraph","daemon"]
    static let literal="literal [a]; 雪\n.txt"
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func require(_ value:Bool,_ message:String,line:UInt = #line)throws {if !value{throw Failure(description:"\(line): \(message)")}}
    @MainActor static var diagnostic:()->String={""}
    @MainActor static func wait(_ message:String,line:UInt = #line,_ ready:()->Bool) async throws {
        for _ in 0..<2400{if ready(){return};try await Task.sleep(nanoseconds:10_000_000)}
        throw Failure(description:"\(line): \(message); \(diagnostic())")
    }
    @MainActor static func board(_ paths:[URL])->NSPasteboard {
        let value=NSPasteboard.withUniqueName()
        value.writeObjects(paths.map{path->NSPasteboardItem in let item=NSPasteboardItem();item.setString(path.absoluteString,forType:.fileURL);return item})
        return value
    }
    @MainActor static func invoke(_ provider:TurtleGitFinderServicesProvider,_ value:NSPasteboard,_ command:String)->NSString? {
        var error:NSString?;provider.performFinderAction(value,userData:command,error:&error);return error
    }
    @MainActor static func idle()->Bool {
        ReferenceLogWindowModel.activeOwnedOperations==0 && ReferenceLogWindowModel.activeRevisionReads==0 &&
        ReferenceBrowserWindowModel.activeReads==0 && ReferenceBrowserWindowModel.activeMutations==0 && ReferenceBrowserWindowModel.activeComparisons==0 && ReferenceBrowserWindowController.activeChildReleases==0 &&
        RepositoryBrowserWindowModel.activeOperations==0 && RepositoryBrowserFileOperation.activeRequests==0 &&
        LogWindowModel.activeHistoryLoads==0 && LogWindowModel.activeReferenceReads==0 && LogWindowModel.activeNoteReads==0 && LogWindowModel.activeNoteSaves==0 &&
        RevisionGraphWindowModel.activeOperations==0 && RevisionGraphWindowController.activeExportOperations==0 && RevisionGraphFilterController.activeOperations==0 && RevisionGraphFindController.activeOperations==0 &&
        GitDaemonWindowModel.activeOperations==0 && GitDaemonWindowModel.activeQuestions==0
    }
    @MainActor static func pending(_ controller:NSWindowController)->Bool {
        switch controller {
        case let value as ReferenceLogWindowController:return value.hasPendingWork
        case let value as ReferenceBrowserWindowController:return value.hasPendingWork
        case let value as RepositoryBrowserWindowController:return value.hasPendingWork
        case let value as RevisionGraphWindowController:return value.hasPendingWork
        case let value as GitDaemonWindowController:return value.hasPendingWork
        default:return false
        }
    }
    @MainActor static func preferences(_ controller:NSWindowController)->UserDefaults? {
        switch controller {
        case let value as ReferenceLogWindowController:return value.model.preferences
        case let value as ReferenceBrowserWindowController:return value.model.preferences
        case let value as RepositoryBrowserWindowController:return value.model.preferences
        case let value as RevisionGraphWindowController:return value.model.preferences
        case let value as GitDaemonWindowController:return value.model.preferences
        default:return nil
        }
    }
    @MainActor static func loaded(_ controller:NSWindowController)->Bool {
        switch controller {
        case let value as ReferenceLogWindowController:return !value.model.busy && value.model.error==nil && value.model.canRefresh
        case let value as ReferenceBrowserWindowController:return !value.model.busy && value.model.snapshot != nil && value.model.error==nil
        case let value as RepositoryBrowserWindowController:return !value.model.busy && value.model.snapshot != nil && value.model.error==nil
        case let value as RevisionGraphWindowController:return !value.model.busy && value.model.geometry != nil && value.model.error==nil
        case let value as GitDaemonWindowController:return value.model.phase == .warning
        default:return false
        }
    }
    @MainActor final class Context {
        let root:URL,git:URL,suite:String,defaults:UserDefaults,otherSuite:String,otherDefaults:UserDefaults
        let store:RepositoryAccessStore,workspace:RepositoryModel,host:NSWindow
        let delegate=TurtleGitApplicationDelegate()
        var windows:[(RepositoryAction,NSWindowController,GitRepository,RepositoryAccessLease?)]=[]
        var logs:[LogWindowController]=[]
        fileprivate var gates:[HistoryServiceDaemonGate]=[]
        var configure:((RepositoryAction,NSWindowController)->Void)?
        var panels:[NSOpenPanel]=[]
        init(root:URL,git:URL,ready:Bool = true)throws {
            self.root=root;self.git=git;suite="TurtleGit.HistoryServices.QA."+UUID().uuidString;defaults=UserDefaults(suiteName:suite)!
            otherSuite=suite+".replacement";otherDefaults=UserDefaults(suiteName:otherSuite)!
            for prefs in [defaults,otherDefaults] {
                prefs.set(false,forKey:"DaemonNoSecurityWarning");prefs.set(false,forKey:"ConfirmKillProcess");prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"UseLibgit2")
            }
            defaults.set(true,forKey:"ShowRevGraphOverview");otherDefaults.set(false,forKey:"ShowRevGraphOverview")
            store=try RepositoryAccessStore(storageURL:root.appendingPathComponent("access.json"),provider:HistoryServiceScopes())
            workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false},savedAccessStore:store,comparisonMarks:WorkingComparisonMarkStore(storageURL:root.appendingPathComponent("marks.json")))
            workspace.repositoryBookmarkProvider=HistoryServiceScopes();workspace.requiresRepositoryScope=true;workspace.fileComparisonPreferences=defaults
            let layout=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("build/Build/Products/Debug/TurtleGitMac.app/Contents/Helpers/GraphLayout/graph-layout")
            workspace.revisionGraphWindowFactory={repository,access,preferences,load in RevisionGraphWindowController(repository:repository,access:access,preferences:preferences,layoutExecutable:layout,automaticallyLoad:load)}
            host=NSWindow(contentRect:NSRect(x:-20000,y:-20000,width:600,height:400),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            host.alphaValue=0;host.isReleasedWhenClosed=false;host.orderFront(nil);workspace.workspaceWindow=host
            workspace.finderServiceWorkflowPresentation={ [weak self] action,controller,repository,access in
                guard let self else{return};controller.window?.alphaValue=0;controller.window?.setFrameOrigin(NSPoint(x:-20000,y:-20000))
                // Defence in depth: even an accidentally remembered Proceed
                // warning can only execute this private, socket-free runner.
                if let daemon=controller as? GitDaemonWindowController {daemon.model.run={_,_,_,_ in 0}}
                self.configure?(action,controller);self.windows.append((action,controller,repository,access))
            }
            workspace.logWindowPresentation={ [weak self] controller in controller.window?.alphaValue=0;controller.window?.setFrameOrigin(NSPoint(x:-20000,y:-20000));self?.logs.append(controller) }
            workspace.presentFinderServiceFolderPanel={ [weak self] panel,parent,reply in
                panel.alphaValue=0;panel.setFrameOrigin(NSPoint(x:-20000,y:-20000));self?.panels.append(panel);parent?.beginSheet(panel,completionHandler:nil)
                Task{@MainActor in await Task.yield();reply(.OK)}
            }
            workspace.selectedFinderServiceFolderURL={_ in root}
            delegate.startupArguments=[];delegate.startupCommandHandler={_,_,_ in}
            if ready{activate()}
        }
        func activate(){delegate.makeStandaloneWorkspace={workspace};delegate.repositoryModel=workspace;delegate.startupDidFinishLaunching()}
        func finish() async throws {
            gates.forEach{$0.release()};delegate.retireFinderServices();workspace.stopMonitoringForTermination()
            windows.forEach{$0.1.close()};logs.forEach{$0.close()}
            for panel in panels{panel.sheetParent?.endSheet(panel,returnCode:.cancel);panel.close()};host.close()
            try await FinderHistoryServicesVerification.wait("history Services owned readers/children retired"){FinderHistoryServicesVerification.idle() && !self.workspace.hasPendingFinderServiceWork && self.windows.allSatisfy{!FinderHistoryServicesVerification.pending($0.1)}}
            defaults.removePersistentDomain(forName:suite);otherDefaults.removePersistentDomain(forName:otherSuite)
        }
        func make(_ name:String)async throws->GitRepository {
            let directory=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let repo=GitRepository(root:directory,executable:git);_ = try await repo.run(["init","-b","main"])
            for (key,value) in [("user.name","History Services QA"),("user.email","qa@example.invalid"),("commit.gpgsign","false"),("core.hooksPath","/dev/null")] {_ = try await repo.run(["config",key,value])}
            try Data("first\n".utf8).write(to:directory.appendingPathComponent(Self.literalPath))
            try await repo.stage([Self.literalPath]);_ = try await repo.commit(message:"baseline")
            try Data("second\n".utf8).write(to:directory.appendingPathComponent(Self.literalPath));try await repo.stage([Self.literalPath]);_ = try await repo.commit(message:"second")
            try Data("new\n".utf8).write(to:directory.appendingPathComponent("added.txt"));try await repo.stage(["added.txt"])
            try Data("untracked\n".utf8).write(to:directory.appendingPathComponent("untracked.txt"))
            return repo
        }
        private static var literalPath:String {FinderHistoryServicesVerification.literal}
        func open(_ repo:GitRepository)async throws {
            try await FinderHistoryServicesVerification.wait("workspace idle before Open"){!self.workspace.busy && !self.workspace.hasPendingRepositoryWork}
            var accepted=false;workspace.open(repo.root,onOpened:{accepted=true})
            try await FinderHistoryServicesVerification.wait("captured workspace Open"){accepted && !self.workspace.busy && self.workspace.root?.path==repo.root.path}
        }
        func launch(_ command:String,paths:[URL],accepted:Bool = true,cold:Bool = false)async throws->NSWindowController? {
            try await FinderHistoryServicesVerification.wait("idle before \(command)"){!self.workspace.busy && !self.workspace.hasPendingRepositoryWork}
            workspace.error=nil;let count=windows.count,selected=FinderHistoryServicesVerification.board(paths);defer{selected.releaseGlobally()}
            let error=FinderHistoryServicesVerification.invoke(delegate.finderServicesProvider,selected,command)
            if !accepted,error != nil{try FinderHistoryServicesVerification.require(windows.count==count,"synchronously refused Service presented");return nil}
            try FinderHistoryServicesVerification.require(error==nil,"Service \(command) synchronous failure: \(String(describing:error))")
            if cold {
                try FinderHistoryServicesVerification.require(delegate.pendingFinderServiceRequest?.action.rawValue==command && delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"cold Service was not queued/accounted for Quit")
                activate()
            }
            try await FinderHistoryServicesVerification.wait("Service \(command) terminal dispatch"){!self.workspace.busy && !self.workspace.hasPendingFinderServiceWork && (self.windows.count>count || self.workspace.error != nil)}
            if !accepted{try FinderHistoryServicesVerification.require(windows.count==count && workspace.error != nil,"ineligible \(command) opened");return nil}
            try FinderHistoryServicesVerification.require(windows.count==count+1,"\(command) actual native handoff missing: \(workspace.error ?? "nil")")
            let found=windows[count]
            try FinderHistoryServicesVerification.require(found.0.rawValue==command && found.1.window?.alphaValue==0 && found.3?.hasSecurityScope==true && found.3?.contains(found.2.root)==true,"history Service lost action, hidden native window or actual primary grant")
            return found.1
        }
    }
    static func value(_ repo:GitRepository,_ args:[String])async throws->String {try await repo.run(args).text.trimmingCharacters(in:.newlines)}
    static func bytes(_ repo:GitRepository,_ path:String)throws->Data {try Data(contentsOf:repo.root.appendingPathComponent(path))}
    @MainActor static func provider()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2]),selected=root.appendingPathComponent("literal [folder]; 雪")
        try FileManager.default.createDirectory(at:selected,withIntermediateDirectories:true)
        let board=board([selected]),multiple=Self.board([selected,root]);defer{board.releaseGlobally();multiple.releaseGlobally()}
        let old=NSApp.servicesProvider;defer{NSApp.servicesProvider=old}
        let marker=NSObject();NSApp.servicesProvider=marker
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in false})
        defer{workspace.stopMonitoringForTermination()}
        for command in commands {
            let delegate=TurtleGitApplicationDelegate();delegate.startupArguments=[];delegate.startupCommandHandler={_,_,_ in}
            var received:[FinderRequest]=[];delegate.workspaceServiceHandler={_,request in received.append(request);return true}
            delegate.installFinderServices()
            try require((NSApp.servicesProvider as AnyObject?) === delegate.finderServicesProvider,"Services provider was not installed")
            let generation=board.changeCount
            try require(invoke(delegate.finderServicesProvider,board,command)==nil && delegate.pendingFinderServiceRequest?.action.rawValue==command,"cold Service did not queue typed request")
            try require(invoke(delegate.finderServicesProvider,board,command) != nil && received.isEmpty,"cold duplicate was silently accepted")
            delegate.makeStandaloneWorkspace={workspace};delegate.repositoryModel=workspace;delegate.startupDidFinishLaunching()
            try await wait("cold provider delivery"){received.count==1}
            try require(received[0].action.rawValue==command && received[0].paths.map(\.path)==[selected.path] && delegate.pendingFinderServiceRequest==nil && board.changeCount==generation,"cold provider changed captured action/path/pasteboard")
            try require(invoke(delegate.finderServicesProvider,board,command)==nil && received.count==2,"active Service did not deliver")
            try require(invoke(delegate.finderServicesProvider,multiple,command) != nil && received.count==2,"history Service accepted multiple selections")
            delegate.retireFinderServices();try require((NSApp.servicesProvider as AnyObject?) === marker,"Services retirement did not restore predecessor")
            try require(invoke(delegate.finderServicesProvider,board,command) != nil && received.count==2,"retired provider dispatched")
        }
        let plist=try PropertyListSerialization.propertyList(from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])),format:nil) as! [String:Any]
        let entries=plist["NSServices"] as? [[String:Any]] ?? []
        try verifyPublicOpenService(entries)
        print("PASS: five cold/active Services,one public declaration and legacy handlers, provider install/restore/retirement, literal singleton capture and folder/item UTIs")
    }
    @MainActor static func routes()async throws {
        let context=try Context(root:URL(fileURLWithPath:CommandLine.arguments[1]),git:URL(fileURLWithPath:CommandLine.arguments[2]),ready:false)
        diagnostic={"root=\(context.workspace.root?.path ?? "nil"),error=\(context.workspace.error ?? "nil"),windows=\(context.windows.map{$0.0.rawValue})"}
        do {
            let a=try await context.make("capturedA"),b=try await context.make("workspaceB")
            try context.store.remember(a.root);try context.store.remember(b.root);try await context.open(b)
            let aIndex=try bytes(a,".git/index"),bIndex=try bytes(b,".git/index"),aConfig=try bytes(a,".git/config"),bHead=try await value(b,["rev-parse","HEAD"])
            for (index,command) in commands.enumerated() {
                let child=try await context.launch(command,paths:[a.root],cold:index==0)!
                try await wait("actual native \(command) contents"){loaded(child)}
                try require(context.windows.last?.2.root.path==a.root.path && preferences(child) === context.defaults && context.windows.last?.3?.contains(b.root)==false,"\(command) used workspace/metadata grant or changed preference owner")
                context.workspace.fileComparisonPreferences=context.otherDefaults;try await context.open(b)
                try require(preferences(child) === context.defaults && context.windows.last?.2.root.path==a.root.path,"workspace replacement retargeted a captured history controller")
                if let graph=child as? RevisionGraphWindowController {
                    try require(graph.model.showOverview,"captured graph preference missing")
                    let prior=context.logs.count;graph.model.selection=[graph.model.nodes[0].hash];graph.model.showLog()
                    try await wait("captured graph Log successor"){context.logs.count==prior+1}
                    try require(context.logs.last?.model.repository.root.path==a.root.path && context.logs.last?.model.colorPreferences === context.defaults,"Graph successor lost captured repository/preferences")
                    context.logs.last?.close()
                }
                if let browser=child as? RepositoryBrowserWindowController {
                    let prior=context.logs.count;browser.model.showFolderLog("")
                    try await wait("captured repository folder Log successor"){context.logs.count==prior+1}
                    try require(context.logs.last?.model.repository.root.path==a.root.path && context.logs.last?.model.colorPreferences === context.defaults,"Repo-browser successor lost captured repository/preferences")
                    context.logs.last?.close()
                }
                child.close();try await wait("native \(command) readers drained"){idle()};context.workspace.fileComparisonPreferences=context.defaults
            }
            let selectedFile=a.root.appendingPathComponent(literal)
            for command in commands {
                let permitted=["revisionGraph","daemon"].contains(command)
                let child=try await context.launch(command,paths:[selectedFile],accepted:permitted)
                if let child{try await wait("tracked-file \(command) loaded"){loaded(child)};child.close();try await wait("tracked-file history drained"){idle()}}
            }
            for command in ["revisionGraph","daemon"] {for path in ["untracked.txt","added.txt"]{_ = try await context.launch(command,paths:[a.root.appendingPathComponent(path)],accepted:false)}}
            let bareURL=context.root.appendingPathComponent("bare.git")
            _ = try await a.run(["clone","--bare","--",a.root.path,bareURL.path])
            for command in commands {
                let child=try await context.launch(command,paths:[bareURL])!
                try await wait("bare \(command) native contents"){loaded(child)}
                try require(context.windows.last?.2.root.path==bareURL.path,"bare history route switched to former workspace")
                child.close();try await wait("bare history readers drained"){idle()}
            }
            let finalA=try bytes(a,".git/index"),finalB=try bytes(b,".git/index"),finalConfig=try bytes(a,".git/config"),finalHead=try await value(b,["rev-parse","HEAD"])
            try require(finalA==aIndex && finalB==bIndex && finalConfig==aConfig && finalHead==bHead,"history Services changed source/unrelated index/config/HEAD")
            try await context.finish();diagnostic={""}
            print("PASS: actual five native history windows, cold and active captured grants/prefs, workspace replacement/successors, tracked/added/untracked gates and bare routes")
        }catch{try? await context.finish();diagnostic={""};throw error}
    }
    static func quoted(_ value:String)->String {"'"+value.replacingOccurrences(of:"'",with:"'\\''")+"'"}
    @MainActor static func ownership()async throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]),realGit=URL(fileURLWithPath:CommandLine.arguments[2])
        let hold=root.appendingPathComponent("hold-read"),started=root.appendingPathComponent("started-read"),release=root.appendingPathComponent("release-read"),wrapper=root.appendingPathComponent("held-history-git")
        let script="""
        #!/bin/bash
        for argument in "$@"; do
          if [[ "$argument" == "--format=%(refname)" ]] && [[ -f \(quoted(hold.path)) ]]; then
            echo "$$" >> \(quoted(root.appendingPathComponent("owned-read-pids").path))
            : > \(quoted(started.path))
            while [[ ! -e \(quoted(release.path)) ]]; do /bin/sleep .02; done
          fi
        done
        exec \(quoted(realGit.path)) "$@"
        """
        try Data(script.utf8).write(to:wrapper);try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:wrapper.path)
        let context=try Context(root:root,git:wrapper)
        diagnostic={"root=\(context.workspace.root?.path ?? "nil"),error=\(context.workspace.error ?? "nil"),windows=\(context.windows.map{String(describing:type(of:$0.1))})"}
        var grantReply:((NSApplication.ModalResponse)->Void)?,saveReply:((NSApplication.ModalResponse)->Void)?
        var browserWriteReply:CheckedContinuation<Void,Never>?
        do {
            let a=try await context.make("authorityA"),b=try await context.make("workspaceB"),c=try await context.make("firstUseC")
            try context.store.remember(a.root);try context.store.remember(b.root);try await context.open(b)
            let originalIndex=try bytes(a,".git/index"),originalC=try bytes(c,".git/index")
            context.workspace.presentFinderServiceFolderPanel={panel,parent,reply in panel.alphaValue=0;context.panels.append(panel);grantReply=reply;parent?.beginSheet(panel,completionHandler:nil)}
            context.workspace.selectedFinderServiceFolderURL={_ in c.root}
            let selected=board([c.root]);defer{selected.releaseGlobally()}
            let count=context.windows.count
            try require(invoke(context.delegate.finderServicesProvider,selected,"referenceBrowser")==nil,"first-use history authority was refused")
            try await wait("first-use history grant sheet"){grantReply != nil && context.host.attachedSheet != nil}
            try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored history grant ownership")
            let staleGrant=grantReply;grantReply?(.cancel);grantReply=nil
            try await wait("history grant cancellation"){!context.workspace.hasPendingFinderServiceWork && context.host.attachedSheet==nil}
            staleGrant?(.OK)
            try require(context.windows.count==count && context.workspace.root?.path==b.root.path && bytes(c,".git/index")==originalC,"late cancelled grant adopted/opened/mutated C")
            try require(invoke(context.delegate.finderServicesProvider,selected,"referenceBrowser")==nil,"replacement first-use grant failed")
            try await wait("replacement history grant"){grantReply != nil};grantReply?(.OK);grantReply=nil
            try await wait("actual first-use reference browser"){context.windows.count==count+1 && !context.workspace.hasPendingFinderServiceWork}
            guard let refs=context.windows.last?.1 as? ReferenceBrowserWindowController else{throw Failure(description:"References missing")}
            try await wait("reference browser ready"){loaded(refs)}
            try require(context.windows.last?.3?.contains(c.root)==true && context.windows.last?.3?.contains(b.root)==false,"first-use history widened captured primary grant")
            let branch=GitReferenceName("refs/heads/main");refs.model.select([branch],last:branch)
            refs.editDescription()
            try await wait("owned branch description child"){refs.descriptionEditor != nil && refs.window?.attachedSheet != nil}
            let description=refs.descriptionEditor;var refsClosed=false;let priorRefsClose=refs.onClosed;refs.onClosed={refsClosed=true;priorRefsClose()}
            refs.close()
            try await wait("reference child/model retirement"){refsClosed && refs.model.closed && description?.window?.sheetParent==nil && idle()}
            // Hold a genuine cancellable Git child beneath RefLog. Retiring its
            // native owner must reap the child before releasing the completion.
            try Data().write(to:hold)
            let reflog=try await context.launch("reflog",paths:[a.root]) as! ReferenceLogWindowController
            try await wait("actual held reflog Git subprocess"){FileManager.default.fileExists(atPath:started.path) && reflog.model.busy}
            try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored history read")
            var reflogClosed=false;let priorClose=reflog.onClosed;reflog.onClosed={reflogClosed=true;priorClose()}
            reflog.close()
            try await wait("held Git child cancellation/drain"){reflogClosed && reflog.model.isInvalidated && ReferenceLogWindowModel.activeOwnedOperations==0}
            try FileManager.default.removeItem(at:hold)
            let replacement=try await context.launch("reflog",paths:[a.root]) as! ReferenceLogWindowController
            try require(replacement !== reflog,"retired RefLog was reused from cache")
            try await wait("replacement RefLog fresh rows"){loaded(replacement)};replacement.close()
            // Actual graph Save sheet keeps the graph owner until detachment;
            // a captured late approval cannot write after forced owner closure.
            let graph=try await context.launch("revisionGraph",paths:[a.root]) as! RevisionGraphWindowController
            try await wait("graph source/layout ready"){loaded(graph)}
            let output=root.appendingPathComponent("must-not-export.emf")
            graph.presentSavePanel={panel,parent,reply in panel.alphaValue=0;parent.beginSheet(panel,completionHandler:nil);saveReply=reply}
            graph.selectedSaveURL={_ in output};graph.saveGraph()
            try await wait("owned native graph save panel"){saveReply != nil && graph.window?.attachedSheet != nil}
            try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored graph save ownership")
            let staleSave=saveReply;var graphClosed=false;let priorGraphClose=graph.onClosed;graph.onClosed={graphClosed=true;priorGraphClose()}
            graph.close();try await wait("graph save panel drained"){graphClosed && !graph.hasPendingWork && graph.window?.attachedSheet==nil}
            staleSave?(.OK);saveReply=nil
            try require(!FileManager.default.fileExists(atPath:output.path),"late graph save approval wrote after retirement")
            // Filter reads reference names in its actual child controller.
            // Hold that real Git subprocess and force-close its graph parent;
            // completion must retain both the child worker and own sheet.
            let filteringGraph=try await context.launch("revisionGraph",paths:[a.root]) as! RevisionGraphWindowController
            try await wait("replacement graph ready for actual Filter"){loaded(filteringGraph)}
            try? FileManager.default.removeItem(at:started)
            try? FileManager.default.removeItem(at:release)
            try Data().write(to:hold)
            filteringGraph.showFilter()
            try await wait("actual graph Filter held reference read"){filteringGraph.filter != nil && RevisionGraphFilterController.activeOperations>0 && FileManager.default.fileExists(atPath:started.path)}
            guard let filter=filteringGraph.filter,let filterWindow=filter.window else{throw Failure(description:"Actual graph Filter child missing")}
            try require(filterWindow.sheetParent === filteringGraph.window && context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Graph Filter lost its actual sheet/worker/Quit ownership")
            let journal=try String(contentsOf:root.appendingPathComponent("owned-read-pids"),encoding:.utf8)
            guard let filterPID=journal.split(separator:"\n").last.flatMap({Int32($0)}),filterPID>0 else{throw Failure(description:"Actual Filter subprocess PID was not recorded")}
            var filteringGraphClosed=false;let priorFilteringClose=filteringGraph.onClosed
            filteringGraph.onClosed={filteringGraphClosed=true;priorFilteringClose()}
            filteringGraph.close()
            try await wait("graph Filter child sheet/read/parent and actual subprocess drained") {
                let gone=Darwin.kill(filterPID,0) == -1 && errno == ESRCH
                return filteringGraphClosed && !filteringGraph.hasPendingWork && RevisionGraphFilterController.activeOperations==0 && filterWindow.sheetParent==nil && gone
            }
            try FileManager.default.removeItem(at:hold)
            // A real Repo-browser historical Save reaches a held writer after
            // its native Save sheet detaches. Cancellation retains both the
            // operation and its owning controller until that writer returns.
            let browser=try await context.launch("repositoryBrowser",paths:[a.root]) as! RepositoryBrowserWindowController
            try await wait("repository browser ready for historical Save"){loaded(browser)}
            let savedFile=root.appendingPathComponent("must-not-save.txt")
            var browserSaveReply:((NSApplication.ModalResponse)->Void)?,browserWriteToken:OperationCancellation?
            browser.presentSavePanel={panel,parent,reply in panel.alphaValue=0;parent.beginSheet(panel,completionHandler:nil);browserSaveReply=reply}
            browser.saveDestination={_ in savedFile}
            browser.writeDocument={data,url,token in
                browserWriteToken=token
                await withCheckedContinuation{browserWriteReply=$0}
                try token.check();try data.write(to:url,options:.atomic)
            }
            guard let entry=browser.model.snapshot?.entries.first(where:{$0.path==literal}) else{throw Failure(description:"Historical literal file missing")}
            browser.model.open(entry,action:.save)
            try await wait("actual historical Save panel"){browserSaveReply != nil && browser.window?.attachedSheet != nil}
            browserSaveReply?(.OK);browserSaveReply=nil
            try await wait("historical writer received captured output"){browserWriteReply != nil && browser.window?.attachedSheet==nil}
            try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored actual Repo-browser writer")
            var browserClosed=false;let priorBrowserClose=browser.onClosed;browser.onClosed={browserClosed=true;priorBrowserClose()}
            browser.close()
            try require(browserWriteToken?.isCancelled==true && !browserClosed && browser.hasPendingWork,"Repo-browser released its owner before the historical writer returned")
            browserWriteReply?.resume();browserWriteReply=nil
            try await wait("historical writer and browser owner drained"){browserClosed && !browser.hasPendingWork}
            try require(!FileManager.default.fileExists(atPath:savedFile.path),"cancelled historical writer published after retirement")
            // The live daemon test is an injected blocking operation only: no
            // network bind, no public server and no external process is started.
            let gate=HistoryServiceDaemonGate();context.gates.append(gate)
            context.configure={action,controller in if action == .daemon,let daemon=controller as? GitDaemonWindowController{daemon.model.run={_,_,token,_ in gate.run(token)}}}
            let daemon=try await context.launch("daemon",paths:[a.root]) as! GitDaemonWindowController
            try require(daemon.model.phase == .warning && gate.startCount==0,"Daemon Service bypassed explicit warning")
            daemon.model.proceed();try await wait("private injected daemon worker"){gate.token != nil && daemon.model.busy}
            let countBefore=context.windows.count
            let same=try await context.launch("daemon",paths:[a.root]) as! GitDaemonWindowController
            try require(same === daemon && gate.startCount==1 && context.windows.count==countBefore+1,"running Daemon Service replaced/restarted its captured worker")
            try require(context.delegate.applicationShouldTerminate(NSApp) == .terminateCancel,"Quit ignored actual daemon worker")
            var daemonClosed=false;let priorDaemonClose=daemon.onClosed;daemon.onClosed={daemonClosed=true;priorDaemonClose()}
            daemon.close()
            try require(gate.token?.isCancelled==true && !daemonClosed && GitDaemonWindowModel.activeOperations>0,"daemon owner released before its cancelled operation returned")
            gate.release();try await wait("daemon operation and owner drained"){daemonClosed && GitDaemonWindowModel.activeOperations==0}
            let finalA=try bytes(a,".git/index"),finalC=try bytes(c,".git/index")
            try require(finalA==originalIndex && finalC==originalC,"history read/child cancellation mutated source index")
            try await context.finish();diagnostic={""}
            print("PASS: owned first-use grants/late rejection, branch child detachment, real held Git child reaping/cache replacement, graph Save late fence, actual Filter sheet/subprocess retirement, actual historical Save writer and private daemon worker/Quit drainage")
        }catch{try? Data().write(to:release);grantReply?(.cancel);saveReply?(.cancel);browserWriteReply?.resume();browserWriteReply=nil;try? await context.finish();diagnostic={""};throw error}
    }
    @MainActor static func main()async throws {
        NSApp.setActivationPolicy(.prohibited)
        let original=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.order(_:relativeTo:)))!,hidden=class_getInstanceMethod(NSWindow.self,#selector(NSWindow.turtleGitHistoryServicesOrder(_:relativeTo:)))!
        method_exchangeImplementations(original,hidden);defer{method_exchangeImplementations(original,hidden)}
        switch ProcessInfo.processInfo.environment["TURTLEGIT_FINDER_HISTORY_SERVICES_CASE"] {
        case "provider":try await provider()
        case "routes":try await routes()
        case "ownership":try await ownership()
        default:throw Failure(description:"Unknown history Services case")
        }
        print("PASS: history Services case completed")
    }
}
private extension NSWindow {
    @objc func turtleGitHistoryServicesOrder(_ place:NSWindow.OrderingMode,relativeTo otherWin:Int){alphaValue=0;turtleGitHistoryServicesOrder(place,relativeTo:otherWin)}
}
