import AppKit
import TurtleGitCore

private final class ServiceDaemonProbe: @unchecked Sendable {
    private let lock=NSLock()
    private var value=0
    func begin() {lock.lock();value += 1;lock.unlock()}
    var starts:Int {lock.lock();defer {lock.unlock()};return value}
}
extension PrimaryCommandsVerification {
    @MainActor static func verifyServiceCommands() async throws {
        let container=URL(fileURLWithPath:CommandLine.arguments[1]),git=URL(fileURLWithPath:CommandLine.arguments[2])
        let suite="TurtleGit.ServiceCommands."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(false,forKey:"VersionCheck");prefs.set(Date(),forKey:"TurtleGit.LastVersionCheck")
        let clipboard=NSPasteboard(name:.init(suite));defer {clipboard.clearContents();prefs.removePersistentDomain(forName:suite)}
        var factories=0
        let noGit=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{_ in factories += 1;throw Failure(description:"Git is unavailable")},snapshotWriter:{_ in true})
        noGit.requiresRepositoryScope=false;noGit.fileComparisonPreferences=prefs
        defer {noGit.stopMonitoringForTermination()}
        @MainActor func utility(_ args:[String]) {noGit.handleCommandLine(arguments:args,currentDirectory:container.path)}
        let updates=ReleaseUpdateService();var displays=0,fetches=0,hold=true,fail=false,store=false
        var response:[PublishedRelease]=[],updateReply:CheckedContinuation<[PublishedRelease],Never>?,models:[ReleaseUpdateModel]=[]
        @MainActor func release(_ tag:String)throws->PublishedRelease {
            let value:[String:Any]=["tag_name":tag,"html_url":"https://github.com/jfk-solutions/turtle-git-mac/releases/tag/"+tag,"draft":false,"prerelease":false,"body":"Private release fixture","assets":[["id":1,"name":"TurtleGit-for-Mac.zip","size":1,"state":"uploaded","digest":"sha256:"+String(repeating:"a",count:64),"browser_download_url":"https://github.com/jfk-solutions/turtle-git-mac/releases/download/"+tag+"/TurtleGit-for-Mac.zip"]]]
            return try JSONDecoder().decode(PublishedRelease.self,from:JSONSerialization.data(withJSONObject:value))
        }
        response=[try release("1.0.0")]
        updates.createModel={preferences in
            let model=ReleaseUpdateModel(preferences:preferences,installed:"1.0.0",repository:"jfk-solutions/turtle-git-mac",appStore:store)
            model.fetch={_,_ in fetches += 1;if fail {throw Failure(description:"private feed failure")};if hold {return await withCheckedContinuation {updateReply=$0}};return response}
            models.append(model);return model
        }
        updates.display={_ in displays += 1}
        defer {updates.cancelBackground();updates.controller?.close()}
        noGit.onUpdateCheck={updates.showCommand(visible:$0,force:$1,preferences:prefs)}
        utility(["--command=updatecheck"])
        try await wait {updateReply != nil}
        let pending=updates.background!
        try require(updates.controller==nil && pending.busy && fetches==1,"Quiet update created a window or skipped explicit checking")
        utility(["--command=updatecheck","--visible"])
        try require(updates.background==nil && updates.controller?.model === pending && fetches==1,"Visible update failed to promote the pending request")
        updateReply?.resume(returning:response);updateReply=nil
        try await wait {!pending.busy && ReleaseUpdateModel.activeOperations==0}
        try require(!pending.available && !pending.canDownload,"Up-to-date visible check offered source downloads without Force")
        let updateWindow=updates.controller,context=pending.context
        utility(["--command=updatecheck","--visible","--force"])
        try require(updates.controller === updateWindow && pending.context==context && pending.available && pending.canDownload && fetches==1,"Force failed to enable the published equal-version release or replaced its context")
        updates.controller?.close()
        // Force also promotes an in-flight quiet request without a second fetch.
        utility(["--command=updatecheck"]);try await wait {updateReply != nil}
        let forced=updates.background!,beforeForce=fetches
        utility(["--command=updatecheck","--force"])
        try require(updates.background === forced && updates.controller==nil && fetches==beforeForce,"Quiet Force restarted pending work")
        updateReply?.resume(returning:response);updateReply=nil
        try await wait {updates.controller?.model === forced && !forced.busy && ReleaseUpdateModel.activeOperations==0}
        try require(forced.available && forced.canDownload,"Quiet forced equal-version result was hidden")
        updates.controller?.close();hold=false
        let shown=displays
        utility(["--command=updatecheck"])
        try await wait {updates.background==nil && ReleaseUpdateModel.activeOperations==0}
        try require(updates.controller==nil && displays==shown && models.last?.retired==true,"Quiet up-to-date check displayed or retained its model")
        fail=true;utility(["--command=updatecheck"])
        try await wait {updates.background==nil && ReleaseUpdateModel.activeOperations==0}
        try require(updates.controller==nil && models.last?.error != nil && models.last?.retired==true,"Quiet feed error published a window or claimed success")
        fail=false;response=[try release("2.0.0")];utility(["--command=updatecheck"])
        try await wait {updates.controller != nil && ReleaseUpdateModel.activeOperations==0}
        try require(updates.controller?.model.available==true && updates.controller?.automatic==false,"Explicit quiet check was blocked by weekly preference/deadline or offered disabled automatic controls")
        updates.controller?.close()
        prefs.set(true,forKey:"VersionCheck");utility(["--command=updatecheck"])
        try await wait {updates.controller != nil && ReleaseUpdateModel.activeOperations==0}
        try require(updates.controller?.automatic==true,"Eligible quiet result lost its automatic footer")
        let automaticWindow=updates.controller!,automaticContext=automaticWindow.model.context,automaticSelection=automaticWindow.model.selected,automaticMessage=automaticWindow.model.message,automaticFetches=fetches
        utility(["--command=updatecheck","--visible","--force"])
        try require(updates.controller === automaticWindow && !automaticWindow.automatic && automaticWindow.model.context==automaticContext && automaticWindow.model.selected==automaticSelection && automaticWindow.model.message==automaticMessage && fetches==automaticFetches,"Manual promotion lost footer, message, selection or existing work")
        updates.controller?.close();utility(["--command=updatecheck"])
        try await wait {updates.controller != nil && ReleaseUpdateModel.activeOperations==0}
        updates.controller?.model.disableAutomatic()
        try require(updates.controller==nil && !prefs.bool(forKey:"VersionCheck"),"Automatic opt-out did not close/write its owning store")
        hold=true;utility(["--command=updatecheck"]);try await wait {updateReply != nil}
        let retired=updates.background!;updates.cancelBackground()
        try require(retired.retired && ReleaseUpdateModel.activeOperations>0,"Cancelled quiet check released backend ownership before return")
        updateReply?.resume(returning:response);updateReply=nil
        try await wait {ReleaseUpdateModel.activeOperations==0}
        try require(updates.controller==nil && retired.release==nil,"Late retired feed result displayed or populated a window")
        store=true;hold=false;let beforeStore=fetches
        utility(["--command=updatecheck","--force"])
        try require(updates.controller?.model.appStore==true && fetches==beforeStore && !updates.controller!.model.canDownload,"App Store Force fetched/downloaded GitHub files")
        updates.controller?.close();utility(["--command=updatecheck"])
        try require(updates.background==nil && updates.controller==nil && fetches==beforeStore,"Quiet App Store check retained a background model or requested a feed")
        // Command-owned Autotext is independent of a Settings page's child owner.
        let tester=AutotextTesterOwner();tester.present={_ in}
        tester.create={AutotextTesterController(model:AutotextTesterModel(preferences:$0,clipboard:clipboard))}
        noGit.onAutotextTest={tester.show(preferences:prefs)}
        defer {tester.close()}
        utility(["--command=autotexttest"])
        let text=tester.controller!,original=text.model
        original.content="draft content";original.pattern="(draft)"
        var words:CheckedContinuation<[String],Never>?
        original.matcher={_,_,_ in await withCheckedContinuation {words=$0}}
        original.scan();try await wait {words != nil}
        utility(["--command=autotexttest"])
        try require(tester.controller === text && original.preferences === prefs && original.content=="draft content" && original.busy,"Repeated Autotext lost its hidden/in-flight draft or preferences")
        text.close();try require(tester.controller==nil && AutotextTesterModel.activeRequests>0,"Autotext owner released a pending scan early")
        words?.resume(returning:["late"]);words=nil
        try await wait {AutotextTesterModel.activeRequests==0}
        try require(original.result.isEmpty,"Retired Autotext scan accepted late results")
        utility(["--command=autotexttest"])
        try require(tester.controller !== text && tester.controller?.model.content.isEmpty==true,"Closed Autotext command did not create a fresh window")
        tester.close()
        let introduction=ApplicationIntroductionService();introduction.display={_ in};noGit.onIntroduction={introduction.show(preferences:prefs)}
        defer {introduction.controller?.close()}
        utility(["--command=rtfm"])
        let intro=introduction.controller!;var explored=0,helped=0
        intro.model.explore={explored += 1;return false};intro.model.help={helped += 1}
        intro.model.openDocuments();utility(["--command=rtfm"])
        try require(introduction.controller === intro && intro.model.error != nil && explored==1,"Introduction lost error/reuse state")
        intro.model.showHelp();intro.model.showHelp();intro.model.openDocuments()
        try require(introduction.controller==nil && helped==1 && explored==1,"Introduction replayed retired Help/Finder actions")
        utility(["--command=rtfm"]);let accepted=introduction.controller!
        accepted.model.explore={explored += 1;return true};accepted.model.openDocuments()
        try require(introduction.controller==nil && explored==2 && noGit.root==nil && factories==0,"Utilities required Git/adopted a checkout or lost Documents acceptance")
        // The command preserves Daemon's warning and running instance. No public listener.
        let root=container.appendingPathComponent("daemon-repository");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let repo=GitRepository(root:root,executable:git);_ = try await repo.run(["init","-b","main"])
        let workspace=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git)},snapshotWriter:{_ in true})
        workspace.requiresRepositoryScope=false;workspace.fileComparisonPreferences=prefs;workspace.commandLineRepositoryPermission={_ in RepositoryAccessLease(url:container)}
        prefs.set(0,forKey:"AutoCloseGitProgress");prefs.set(false,forKey:"ConfirmKillProcess");prefs.removeObject(forKey:"DaemonNoSecurityWarning")
        let probe=ServiceDaemonProbe();var daemonWindows:[GitDaemonWindowController]=[]
        workspace.daemonConfiguration.listenAddresses=["127.0.0.1"];workspace.daemonConfiguration.port=19418
        workspace.daemonPresentation={controller in
            if !daemonWindows.contains(where:{$0 === controller}) {daemonWindows.append(controller)}
            controller.model.run={_,_,token,emit in probe.begin();emit(.init(stream:.stderr,data:Data("Ready to rumble\n".utf8)));while !token.isCancelled {usleep(1000)};return 0}
        }
        defer {daemonWindows.forEach {$0.close()};workspace.stopMonitoringForTermination();for window in NSApp.windows {window.close()}}
        @MainActor func daemon(_ location:URL) {workspace.handleCommandLine(arguments:["--command=daemon","--path",location.path],currentDirectory:container.path)}
        daemon(root);try await wait {!workspace.busy && !daemonWindows.isEmpty}
        let server=daemonWindows[0]
        try require(workspace.root?.path==root.path && server.model.phase == .warning && server.model.preferences === prefs && probe.starts==0,"Daemon command bypassed warning/adoption/preferences")
        daemon(root);try await wait {!workspace.busy}
        try require(daemonWindows.count==1 && probe.starts==0,"Repeated warning command replaced its window or started serving")
        server.model.rememberWarning=true;server.model.proceed()
        try await wait {server.model.busy && probe.starts==1}
        daemon(root);try await wait {!workspace.busy}
        try require(daemonWindows.count==1 && probe.starts==1 && prefs.bool(forKey:"DaemonNoSecurityWarning"),"Repeated running command restarted the server or lost remembered Proceed")
        server.model.cancel();try await wait {!server.model.busy && GitDaemonWindowModel.activeOperations==0}
        try require(server.model.cancelled,"Daemon command lost cancellation result");server.close()
        prefs.removeObject(forKey:"DaemonNoSecurityWarning")
        let bare=container.appendingPathComponent("bare.git");_ = try await repo.run(["init","--bare",bare.path])
        daemon(bare);try await wait {!workspace.busy && daemonWindows.count==2}
        let bareWindow=daemonWindows[1];bareWindow.model.rememberWarning=true;bareWindow.model.cancel()
        try require(workspace.bare && !prefs.bool(forKey:"DaemonNoSecurityWarning") && probe.starts==1,"Bare daemon entry or Abort warning persistence differs from source")
        try require(ReleaseUpdateModel.activeOperations==0 && AutotextTesterModel.activeRequests==0 && GitDaemonWindowModel.activeOperations==0,"Service command owner leaked")
        print("PASS: Service command family: no-Git utilities; quiet/visible/forced update coalescing, equal/new/error results, download gate, late cancellation and Store isolation; owned Autotext draft/scan reuse and retirement; introduction Help/Documents/error/replay guards; normal/bare Daemon source warning, preferences, singleton run and cancellation. All windows closed. Feed, matcher and server responses injected; no public network, Finder/Help launch or real sandbox issuance.")
    }
}
