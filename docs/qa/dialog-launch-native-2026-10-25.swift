// SPDX-License-Identifier: GPL-2.0-or-later
import AppKit
import Carbon
import TurtleGitCore

@MainActor enum DialogLaunchVerification {
    struct Failure:Error,CustomStringConvertible {let description:String}
    static func phase(_ message:String) {fputs("Dialog launch phase: "+message+"\n",stderr);fflush(stderr)}
    static func require(_ value:Bool,_ message:String)throws {if !value {throw Failure(description:"Dialog launch: "+message)}}
    static func wait(_ message:String,_ ready:()->Bool)async throws {for _ in 0..<3000 {if ready(){return};try await Task.sleep(nanoseconds:10_000_000)};throw Failure(description:"Dialog launch timeout: "+message)}
    static func children(since baseline:Set<ObjectIdentifier>)->[NSWindowController] {
        NSApp.windows.filter{!baseline.contains(ObjectIdentifier($0))}.compactMap(\.windowController)
    }
    static func closeChildren(since baseline:Set<ObjectIdentifier>)async throws {
        let controllers=children(since:baseline)
        for controller in controllers {controller.close()}
        try await wait("owned dialog children drain") {TurtleGitAboutController.activeReads==0 && LogWindowModel.activeHistoryLoads==0 && controllers.allSatisfy{$0.window?.attachedSheet==nil && $0.window?.sheetParent==nil && $0.window?.isVisible != true}}
    }
    /// Exercise the public event manager dispatch path, not the delegate method.
    static func dispatchURL(_ text:String)throws {
        let event=NSAppleEventDescriptor(eventClass:AEEventClass(kInternetEventClass),eventID:AEEventID(kAEGetURL),targetDescriptor:NSAppleEventDescriptor(processIdentifier:ProcessInfo.processInfo.processIdentifier),returnID:AEReturnID(kAutoGenerateReturnID),transactionID:AETransactionID(kAnyTransactionID))
        event.setParam(NSAppleEventDescriptor(string:text),forKeyword:AEKeyword(keyDirectObject))
        let reply=NSAppleEventDescriptor.null()
        guard let rawEvent=event.aeDesc,let rawReply=reply.aeDesc else {
            throw Failure(description:"Apple-event descriptor allocation failed")
        }
        var ownedRefCon:UInt8=0
        _ = withUnsafeMutablePointer(to:&ownedRefCon) { pointer in
            NSAppleEventManager.shared().dispatchRawAppleEvent(rawEvent,withRawReply:UnsafeMutablePointer(mutating:rawReply),handlerRefCon:UnsafeMutableRawPointer(pointer))
        }
    }
    static func verifyCommitReopen(delegate:TurtleGitApplicationDelegate,repository:GitRepository,presentations:()->Int,expectedWorkspace:NSWindow?)async throws {
        phase("Commit child constructing")
        let suite="TurtleGit.DialogReopen.Commit."+UUID().uuidString,prefs=UserDefaults(suiteName:suite)!
        prefs.set(true,forKey:"HintStagingMode");prefs.set(1,forKey:"CommitMergeHint");prefs.set(7,forKey:"NothingToCommitShowUnversioned");prefs.set(false,forKey:"Autocompletion");prefs.set(false,forKey:"UseLibgit2")
        defer {prefs.removePersistentDomain(forName:suite)}
        let head=try await repository.run(["rev-parse","HEAD"]).stdout,index=try await repository.run(["ls-files","--stage","-z"]).stdout
        let child=CommitWindowController(repository:repository,access:nil,defaults:prefs)
        defer {child.close()}
        child.showWindow(nil);child.model.reload()
        try await wait("actual Commit reopen child ready") {!child.model.busy && CommitWindowModel.activeReloads==0 && CommitWindowModel.activePreferenceOperations==0}
        phase("Commit child loaded")
        guard let window=child.window else {throw Failure(description:"Actual Commit window missing")}
        child.model.message="Unsaved standalone Commit draft 雪\nsecond line"
        let draft=child.model.message,before=presentations(),windows=Set(NSApp.windows.map(ObjectIdentifier.init))
        try require(delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true) && presentations()==before && child.window === window && child.model.message==draft && Set(NSApp.windows.map(ObjectIdentifier.init))==windows,"Reopen changed actual Commit draft/owner or created workspace")
        phase("Commit child visible reopen retained")
        let sheet=NSWindow(contentRect:.init(x:-24000,y:-24000,width:300,height:120),styleMask:[.titled],backing:.buffered,defer:false)
        sheet.isReleasedWhenClosed=false;sheet.alphaValue=0
        defer {if let parent=sheet.sheetParent {parent.endSheet(sheet)};sheet.orderOut(nil);sheet.close()}
        window.beginSheet(sheet,completionHandler:nil)
        try require(window.attachedSheet === sheet,"Owned Commit activation sheet did not attach")
        try require(delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true) && presentations()==before && window.attachedSheet === sheet && child.model.message==draft,"Reopen dismissed actual Commit child sheet or lost draft")
        phase("Commit child sheet reopen retained; ending sheet")
        window.endSheet(sheet);sheet.orderOut(nil);sheet.close()
        phase("Commit child miniaturizing")
        window.miniaturize(nil)
        try await wait("actual minimized Commit child") {window.isMiniaturized}
        phase("Commit child miniaturized")
        // AppKit explicitly counts miniaturized windows as visible for this flag.
        try require(delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true) && presentations()==before && window.isMiniaturized && child.model.message==draft,"Minimized child reopen was replaced by workspace")
        phase("Commit child minimized reopen retained; restoring")
        window.deminiaturize(nil)
        try await wait("owned Commit restored") {!window.isMiniaturized}
        try require(delegate.repositoryModel?.workspaceWindow === expectedWorkspace,"Child reopen replaced existing workspace owner")
        phase("Commit child closing")
        child.close()
        try await wait("actual Commit activation child drain") {CommitWindowModel.activeReloads==0 && CommitWindowModel.activePreferenceOperations==0 && CommitWindowModel.activeMetadataOperations==0 && child.window?.isVisible != true && child.window?.attachedSheet==nil}
        let afterHead=try await repository.run(["rev-parse","HEAD"]).stdout,afterIndex=try await repository.run(["ls-files","--stage","-z"]).stdout
        try require(afterHead==head && afterIndex==index,"Activation changed repository HEAD/index")
        phase("Commit child drained; HEAD/index retained")
    }
    static func verify(repository:GitRepository,existing:RepositoryModel,preferences:UserDefaults)async throws {
        phase("begin")
        let git=repository.executable,folder=repository.root
        var models=[RepositoryModel](),delegates=[TurtleGitApplicationDelegate](),settings=[SettingsPresentationService](),appearances=[AppAppearance]()
        defer {
            for delegate in delegates {delegate.retireInboundURLBridge();delegate.retireFinderServices();delegate.workspaceOpenHandoff.retire();delegate.actionErrorController?.close()}
            for model in models {model.stopMonitoringForTermination()}
            for service in settings {service.controller?.close()}
        }
        func configure(_ delegate:TurtleGitApplicationDelegate)throws->RepositoryModel {
            delegate.startupMergeToolExit={status in
                fputs("UNEXPECTED dialog launch tool-exit callback status=\(status)\n"+Thread.callStackSymbols.joined(separator:"\n")+"\n",stderr)
                fflush(stderr)
                exit(status)
            }
            // A real persisted private bookmark grants the selected repository
            // to both CLI and later Finder requests. No interactive system panel
            // or user bookmark archive belongs to this offscreen receiver.
            let provider=RegistrationBookmarks()
            let store=try RepositoryAccessStore(storageURL:folder.deletingLastPathComponent().appendingPathComponent("dialog-access-"+UUID().uuidString+".json"),provider:provider)
            let saved=try store.remember(folder),grant=try store.acquire(saved.id,requireSecurityScope:true)
            try require(grant.hasSecurityScope && grant.contains(folder),"Private dialog repository grant was not acquired")
            let model=RepositoryModel(startMonitoring:false,initializePreferences:false,repositoryFactory:{GitRepository(root:$0,executable:git,libgit2Configuration:.init(enabled:false))},snapshotWriter:{_ in true},savedAccessStore:store)
            model.requiresRepositoryScope=true;model.repositoryBookmarkProvider=provider
            model.commandLineRepositoryPermission={paths in
                try require(paths.allSatisfy{grant.contains($0)},"CLI requested a repository outside its owned grant")
                return grant
            }
            model.fileComparisonPreferences=preferences;models.append(model)
            let appearance=AppAppearance(preferences:preferences),service=SettingsPresentationService();appearances.append(appearance);settings.append(service)
            delegate.makeStandaloneWorkspace={model}
            delegate.configureStandaloneServices={workspace,_ in service.install(workspace:workspace,appearance:appearance)}
            delegate.startupDirectory=folder.path;delegates.append(delegate);return model
        }
        // A URL launch may arrive without OpenConfiguration.arguments. Capture
        // real Apple-event delivery before startup and refuse a default workspace.
        let eventDelegate=TurtleGitApplicationDelegate(),eventModel=try configure(eventDelegate)
        eventDelegate.startupArguments=[];eventDelegate.configureGeneralApplication={_ in}
        var eventPresentations=0,eventURLs=[URL]()
        eventDelegate.presentWorkspace={eventPresentations += 1}
        eventDelegate.activateStandaloneApplication={}
        eventDelegate.workspaceOpenHandler={target,url in
            if target === eventModel {eventURLs.append(url)}
        }
        eventDelegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        let eventActions:[RepositoryAction]=[.registerRepository,.clone,.settings,.about,.help]
        let eventURLsExpected=try eventActions.map {action -> URL in
            guard let url=FinderRequest(action:action,paths:[folder]).url else {throw Failure(description:"Event action URL unavailable")}
            return url
        }
        for url in eventURLsExpected {try dispatchURL(url.absoluteString)}
        try require(eventURLs.isEmpty,"Cold GetURL bypassed startup ownership")
        eventDelegate.startupDidFinishLaunching(defaultLaunch:true)
        // Native startup admits Git-backed URLs only after its actual async
        // configuration-permission restoration returns. Startup's synchronous
        // method returning is not that receipt; keep the real gate and then
        // check the complete FIFO cohort and no-default-workspace invariant.
        try await wait("cold GetURL configuration ownership drained") {eventDelegate.gitConfigurationReadsReady}
        try require(eventURLs==eventURLsExpected && eventPresentations==0 && eventModel.workspaceWindow==nil,"Cold GetURL queue lost routing/order or created default workspace")
        try dispatchURL(eventURLsExpected[0].absoluteString)
        try dispatchURL(eventURLsExpected[0].absoluteString)
        try require(eventURLs.count==eventURLsExpected.count+2,"Repeated warm GetURL was dropped or delivered twice")
        for invalid in ["https://example.invalid/", "turtlegit://unknown", "turtlegit://workspace?unexpected=1", "turtlegit://workspace\0"] {try dispatchURL(invalid)}
        try require(eventURLs.count==eventURLsExpected.count+2 && eventPresentations==0,"Malformed GetURL entered routing")
        // Replacement owns the global event slot; retiring its predecessor must
        // neither remove that slot nor steal it back at a deferred boundary.
        eventDelegate.finishInstallingInboundURLBridge() // queues the actual launch reassertion
        let successor=TurtleGitApplicationDelegate(),successorModel=try configure(successor)
        successor.startupArguments=["--turtlegit-action-only"];successor.activateStandaloneApplication={}
        var successorURLs=[URL]()
        successor.workspaceOpenHandler={target,url in if target === successorModel {successorURLs.append(url)}}
        successor.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        successor.startupDidFinishLaunching()
        eventDelegate.retireInboundURLBridge()
        eventDelegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        await Task.yield()
        // Drain the queued launch reassertion before testing the successor.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        try dispatchURL(eventURLsExpected[0].absoluteString)
        // A fresh action-only successor requests the same real configuration
        // gate on its first URL; the preceding main-queue drain only settled
        // event-slot reassertion, not a preparation that had not started yet.
        try await wait("successor GetURL configuration ownership drained") {successor.gitConfigurationReadsReady}
        try require(successorURLs==[eventURLsExpected[0]] && eventURLs.count==eventURLsExpected.count+2,"Old handler retirement removed successor or redelivered URL")
        successor.retireInboundURLBridge()
        successor.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        try dispatchURL(eventURLsExpected[0].absoluteString)
        try require(successorURLs.count==1,"Retired handler accepted late GetURL")
        eventModel.stopMonitoringForTermination();successorModel.stopMonitoringForTermination()
        // Tool processes hand every accepted external URL to their existing
        // separate-host handoff, never to the waiting Git tool's own workspace.
        phase("cold/warm URL delivery ownership retained")
        for marker in ["--merge-tool","--unified-diff"] {
            phase("tool handoff "+marker)
            let tool=TurtleGitApplicationDelegate(),toolModel=try configure(tool)
            tool.startupArguments=[marker];tool.activateStandaloneApplication={}
            tool.startupCommandHandler={_,_,_ in}
            var forwarded=[[URL]](),toolPresentations=0
            tool.presentWorkspace={toolPresentations += 1}
            tool.workspaceOpenHandoff.launch={urls,_,_,reply in forwarded.append(urls);reply(nil)}
            tool.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
            tool.startupDidFinishLaunching()
            try dispatchURL(eventURLsExpected[0].absoluteString)
            let patch=folder.appendingPathComponent("literal Café.patch")
            try dispatchURL(patch.absoluteString)
            try require(forwarded==[[eventURLsExpected[0]],[patch]] && toolPresentations==0 && toolModel.workspaceWindow==nil && !tool.workspaceOpenHandoff.hasPendingWork,"Tool GetURL escaped existing separate-host handoff: "+marker)
            tool.retireInboundURLBridge();tool.workspaceOpenHandoff.retire();toolModel.stopMonitoringForTermination()
        }

        let internalDelegate=TurtleGitApplicationDelegate(),internalModel=try configure(internalDelegate)
        var internalPresentations=0,internalActivations=0
        internalDelegate.startupArguments=["--turtlegit-action-only"]
        internalDelegate.presentWorkspace={internalPresentations += 1};internalDelegate.activateStandaloneApplication={internalActivations += 1}
        internalDelegate.startupDidFinishLaunching()
        try require(internalDelegate.startupLaunchMode == .actionOnly && internalPresentations==0 && internalActivations==0 && internalModel.workspaceWindow==nil,"Bare action-only bootstrap presented/activated workspace")
        internalDelegate.retireFinderServices();internalModel.stopMonitoringForTermination()
        phase("internal bare bootstrap retained")
        for command in ["about","settings","log"] {
            phase("cold command "+command+" starting")
            let baseline=Set(NSApp.windows.map(ObjectIdentifier.init)),delegate=TurtleGitApplicationDelegate(),model=try configure(delegate)
            var workspacePresentations=0,forcedActivations=0
            delegate.presentWorkspace={workspacePresentations += 1};delegate.activateStandaloneApplication={forcedActivations += 1}
            delegate.startupArguments=["/command:"+command,"/path:"+folder.path]
            try require(delegate.startupLaunchMode == .actionOnly,"Cold command did not select action-only scene: "+command)
            delegate.startupDidFinishLaunching()
            try await wait("cold actual "+command) {
                switch command {
                case "about":return children(since:baseline).contains{$0 is TurtleGitAboutController}
                case "settings":return settings.last?.controller != nil
                default:return children(since:baseline).compactMap{$0 as? LogWindowController}.contains{$0.model.repository.root.path==folder.path && !$0.model.busy}
                }
            }
            try require(delegate.actionRepositoryModel === model && model.workspaceWindow==nil && workspacePresentations==0 && forcedActivations==1 && !delegate.applicationShouldOpenUntitledFile(NSApp),"Cold CLI action lost dialog activation or presented a workspace: "+command)
            try require(delegate.actionErrorController==nil,"Cold valid action produced error: "+command)
            phase("cold command "+command+" presented")
            let actionChildren=children(since:baseline),actionWindows=actionChildren.compactMap(\.window)
            let beforeReopenWindows=Set(NSApp.windows.map(ObjectIdentifier.init)),beforeReopenActivations=forcedActivations
            try require(delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true),"Visible cold dialog did not retain normal AppKit reopen: "+command)
            try require(workspacePresentations==0 && forcedActivations==beforeReopenActivations && model.workspaceWindow==nil && Set(NSApp.windows.map(ObjectIdentifier.init))==beforeReopenWindows && actionChildren.allSatisfy{child in actionWindows.contains{$0 === child.window}},"Visible cold dialog reopen created/replaced/activated workspace: "+command)
            phase("cold command "+command+" visible reopen retained")
            // Explicit Open is deliberately a new workspace intent, whereas the
            // action above must never have launched it implicitly.
            var forwarded=[[URL]](),configurations=[[String]]()
            delegate.workspaceOpenHandoff.launch={urls,_,configuration,reply in forwarded.append(urls);configurations.append(configuration.arguments);reply(nil)}
            guard let registration=FinderRequest(action:.registerRepository,paths:[folder]).url,let log=FinderRequest(action:.log,paths:[folder]).url else{throw Failure(description:"Action handoff URL unavailable")}
            var actionConfigurations=[([String],Bool)]()
            let handoff=WorkspaceOpenHandoff()
            handoff.launch={_,_,configuration,reply in actionConfigurations.append((configuration.arguments,configuration.activates));reply(nil)}
            handoff.submit([registration]);handoff.submit([log])
            try require(actionConfigurations.count==2 && actionConfigurations[0].0==["--turtlegit-action-only"] && !actionConfigurations[0].1 && actionConfigurations[1].0==["--turtlegit-action-only"] && actionConfigurations[1].1 && !handoff.hasPendingWork,"Action handoff lost dialog-only launch or registration activation policy")
            handoff.retire()
            let explicitHost=NSWindow(contentRect:.init(x:-24000,y:-24000,width:500,height:300),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            explicitHost.isReleasedWhenClosed=false;explicitHost.alphaValue=0;model.workspaceWindow=explicitHost
            defer {explicitHost.close();if model.workspaceWindow === explicitHost {model.workspaceWindow=nil}}
            delegate.requestWorkspace()
            try require(workspacePresentations==1 && forwarded.isEmpty && configurations.isEmpty && delegate.repositoryModel === model,"Explicit workspace request did not retain in-process presentation")
            try require(actionChildren.allSatisfy{child in actionWindows.contains{$0 === child.window} && child.window?.isVisible==true},"Explicit workspace intent retired the still-open action dialog: "+command)
            var opened=[[URL]]()
            delegate.workspaceOpenSelectionHandler={target,paths in
                guard target === model else {return false};opened.append(paths);return true
            }
            let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()};board.writeObjects([folder as NSURL])
            var error:NSString?;delegate.finderServicesProvider.openInTurtleGit(board,userData:"open",error:&error)
            try require(error==nil && opened.count==1 && opened[0].map(\.path)==[folder.path] && forwarded.isEmpty,"Generic public Service did not explicitly route workspace Open")
            phase("cold command "+command+" explicit Open retained; closing")
            try await closeChildren(since:baseline)
            phase("cold command "+command+" drained")
            delegate.retireFinderServices();model.stopMonitoringForTermination()
        }
        let originalRoot=existing.root,originalWindow=existing.workspaceWindow
        let delegate=TurtleGitApplicationDelegate(),privateModel=try configure(delegate)
        var requested=0;delegate.startupArguments=[];delegate.repositoryModel=existing;delegate.presentWorkspace={requested += 1};delegate.startupDidFinishLaunching()
        delegate.applicationWillFinishLaunching(Notification(name:NSApplication.willFinishLaunchingNotification))
        for action in [RepositoryAction.about,.settings,.log] {
            phase("warm action "+action.rawValue+" starting")
            let baseline=Set(NSApp.windows.map(ObjectIdentifier.init)),before=requested
            guard let url=FinderRequest(action:action,paths:[folder]).url else{throw Failure(description:"Action URL unavailable")}
            try dispatchURL(url.absoluteString)
            try await wait("warm actual "+action.rawValue) {
                switch action {
                case .about:return children(since:baseline).contains{$0 is TurtleGitAboutController}
                case .settings:return children(since:baseline).contains{$0.window?.title.contains("Settings")==true}
                default:return children(since:baseline).compactMap{$0 as? LogWindowController}.contains{$0.model.repository.root.path==folder.path && !$0.model.busy}
                }
            }
            try require(existing.root==originalRoot && existing.workspaceWindow===originalWindow && requested==before && delegate.actionRepositoryModel === privateModel && privateModel.workspaceWindow==nil,"Warm dialog retargeted/presented existing workspace: "+action.rawValue)
            let warmWindows=Set(NSApp.windows.map(ObjectIdentifier.init))
            try require(delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true) && requested==before && Set(NSApp.windows.map(ObjectIdentifier.init))==warmWindows && existing.workspaceWindow===originalWindow,"Warm visible dialog reopen presented/retargeted workspace: "+action.rawValue)
            if action == .settings {
                guard let owner=children(since:baseline).first(where:{$0.window?.contentViewController is SettingsNavigationController}),let navigation=owner.window?.contentViewController as? SettingsNavigationController else {throw Failure(description:"Actual private Settings navigation missing")}
                var dirty=true
                navigation.transaction.register("launch-dirty",participant:.init(page:.git,modified:{dirty},validate:{nil},apply:{dirty=false;return true},cancel:{dirty=false}))
                phase("warm Settings dirty Quit refusal")
                try require(delegate.applicationShouldTerminate(NSApp) == .terminateCancel && dirty && navigation.transaction.modified && !navigation.completionPending,"Quit discarded/retired dirty private Settings")
                guard let settingsWindow=owner.window,let sheet=settingsWindow.attachedSheet else {throw Failure(description:"Dirty private Settings did not retain its owned warning sheet")}
                let heldController=owner,heldNavigation=navigation,beforeSheetReopen=requested
                try require(delegate.applicationShouldHandleReopen(NSApp,hasVisibleWindows:true) && requested==beforeSheetReopen && settingsWindow.attachedSheet === sheet && owner === heldController && owner.window?.contentViewController === heldNavigation && dirty && navigation.transaction.modified && !navigation.completionPending,"Reopen replaced dirty scoped Settings, dismissed its sheet or requested workspace")
                phase("warm Settings dirty sheet reopen retained; ending sheet")
                settingsWindow.endSheet(sheet);sheet.close()
                navigation.transaction.unregister("launch-dirty")
            }
            try await closeChildren(since:baseline)
        }
        try await verifyCommitReopen(delegate:delegate,repository:repository,presentations:{requested},expectedWorkspace:originalWindow)
        phase("final explicit workspace request")
        delegate.requestWorkspace();try require(requested==1 && existing.workspaceWindow===originalWindow,"Explicit warm workspace request lost existing route")
        delegate.retireFinderServices();privateModel.stopMonitoringForTermination()
        phase("all dialog activation scenarios complete")
    }
}
